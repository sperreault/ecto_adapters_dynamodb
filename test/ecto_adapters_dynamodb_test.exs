defmodule Ecto.Adapters.DynamoDB.Test do
  @moduledoc """
  Unit tests for the adapter's main public API.
  """

  use ExUnit.Case

  import Ecto.Query

  alias Ecto.Adapters.DynamoDB.TestRepo
  alias Ecto.Adapters.DynamoDB.TestSchema.{Person, Address, BookPage, Planet}

  setup_all do
    TestHelper.setup_all()

    on_exit(fn ->
      TestHelper.on_exit()
    end)
  end


  test "get - no matching record" do
    result = TestRepo.get(Person, "person-faketestperson")
    assert result == nil
  end

  test "query - empty list param" do
    result = TestRepo.all(from p in Person, where: p.id in [])
    assert result == []
  end

  test "insert and get - embedded records, source-mapped field, naive_datetime_usec and utc_datetime" do
    {:ok, insert_result} = TestRepo.insert(%Person{
                             id: "person:address_test",
                             first_name: "Ringo",
                             last_name: "Starr",
                             email: "ringo@test.com",
                             age: 76,
                             country: "England",
                             addresses: [
                               %Address{
                                 street_number: 245,
                                 street_name: "W 17th St"
                               },
                               %Address{
                                 street_number: 1385,
                                 street_name: "Broadway"
                               }
                             ]
                           })

    assert length(insert_result.addresses) == 2
    assert get_datetime_type(insert_result.inserted_at) == :naive_datetime_usec
    assert get_datetime_type((insert_result.addresses |> Enum.at(0)).updated_at) == :utc_datetime
    assert insert_result.country == "England"
    assert insert_result.__meta__ == %Ecto.Schema.Metadata{
                                        state: :loaded,
                                        source: "test_person",
                                        schema: Person
                                      }

    get_result = TestRepo.get(Person, insert_result.id)
    assert get_result == insert_result
  end

  test "update" do
    TestRepo.insert(%Person{
                      id: "person-update",
                      first_name: "Update",
                      last_name: "Test",
                      age: 12,
                      email: "update@test.com",
                    })
    {:ok, result} = TestRepo.get(Person, "person-update")
                    |> Ecto.Changeset.change([first_name: "Updated", last_name: "Tested"])
                    |> TestRepo.update()

    assert result.first_name == "Updated"
    assert result.last_name == "Tested"
  end

  test "insert_all" do
    # single
    total_records = 1
    people = make_list_of_people_for_batch_insert(total_records)
    result = TestRepo.insert_all(Person, people)

    assert result == {total_records, nil}

    # multiple
    # DynamoDB has a constraint on the call to BatchWriteItem, where attempts to insert more than
    # 25 records will be rejected. We allow the user to call insert_all() for more than 25 records
    # by breaking up the requests into blocks of 25.
    # https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_BatchWriteItem.html
    total_records = 55
    people = make_list_of_people_for_batch_insert(total_records)
    result = TestRepo.insert_all(Person, people)

    assert result == {total_records, nil}
  end

  describe "update_all and query" do
    test "update_all - hash primary key query with hard-coded params" do
      person1 = %{
                  id: "person-george",
                  first_name: "George",
                  last_name: "Washington",
                  age: 70,
                  email: "george@washington.com"
                }
      person2 = %{
                  id: "person-thomas",
                  first_name: "Thomas",
                  last_name: "Jefferson",
                  age: 27,
                  email: "thomas@jefferson.com"
                }

      TestRepo.insert_all(Person, [person1, person2])

      from(p in Person, where: p.id in ["person-george", "person-thomas"])
      |> TestRepo.update_all(set: [last_name: nil])

      result = from(p in Person, where: p.id in ["person-george", "person-thomas"], select: p.last_name)
              |> TestRepo.all()

      assert result == [nil, nil]
    end

    test "update_all - composite primary key query with pinned variable params" do
      page1 = %{
                id: "page:test-3",
                page_num: 1,
                text: "abc",
              }
      page2 = %{
                id: "page:test-4",
                page_num: 2,
                text: "def",
              }

      TestRepo.insert_all(BookPage, [page1, page2])

      ids = [page1.id, page2.id]
      pages = [1, 2]

      from(bp in BookPage, where: bp.id in ^ids and bp.page_num in ^pages)
      |> TestRepo.update_all(set: [text: "Call me Ishmael..."])

      result = from(bp in BookPage, where: bp.id in ^ids and bp.page_num in ^pages, select: bp.text)
               |> TestRepo.all()

      assert result == ["Call me Ishmael...", "Call me Ishmael..."]
    end
  end

  test "delete" do
    {:ok, person} = TestRepo.insert(%Person{
                 id: "person:delete",
                 first_name: "Delete",
                 age: 37,
                 email: "delete@test.com",
               })

    TestRepo.delete(person)

    assert TestRepo.get(Person, person.id) == nil
  end

  test "delete_all" do
    person_1 = %{
                 id: "person:delete_all_1",
                 first_name: "Delete",
                 age: 26,
                 email: "delete_all@test.com",
               }
    person_2 = %{
                 id: "person:delete_all_2",
                 first_name: "Delete",
                 age: 97,
                 email: "delete_all@test.com",
               }

    TestRepo.insert_all(Person, [person_1, person_2])

    result = TestRepo.delete_all((from p in Person, where: p.id in ^[person_1.id, person_2.id]))

    assert {2, nil} == result
  end

  describe "update, get_by" do
    test "update and get_by record using a hash and range key, utc_datetime_usec" do
      assert {:ok, book_page} = TestRepo.insert(%BookPage{
        id: "gatsby",
        page_num: 1
      })

      {:ok, _} = BookPage.changeset(book_page, %{text: "Believe"})
      |> TestRepo.update()

      result = TestRepo.get_by(BookPage, [id: "gatsby", page_num: 1])

      assert %BookPage{text: "Believe"} = result
      assert get_datetime_type(result.inserted_at) == :utc_datetime_usec
    end

    test "update a record using the legacy :range_key option, naive_datetime" do
      assert 1 == length(Planet.__schema__(:primary_key)), "the schema have a single key declared"
      assert {:ok, planet} = TestRepo.insert(%Planet{
        id: "neptune",
        name: "Neptune",
        mass: 123245
      })
      assert get_datetime_type(planet.inserted_at) == :naive_datetime

      {:ok, updated_planet} =
        Ecto.Changeset.change(planet, mass: 0)
        |> TestRepo.update(range_key: {:name, planet.name})

      assert %Planet{
        __meta__: %Ecto.Schema.Metadata{
          state: :loaded,
          source: "test_planet",
          schema: Planet
        },
        mass: 0
      } = updated_planet

      {:ok, _} =
        TestRepo.delete(%Planet{id: planet.id}, range_key: {:name, planet.name})
    end  
  end

  describe "query" do
    test "query on composite primary key, hash and hash + range" do
      name = "houseofleaves"
      page_1 = %BookPage{
                id: name,
                page_num: 1,
                text: "abc",
              }
      page_2 = %BookPage{
                id: name,
                page_num: 2,
                text: "def",
              }
      duplicate_page = %BookPage{
                         id: name,
                         page_num: 1,
                         text: "ghi",
                       }
      {:ok, page_1} = BookPage.changeset(page_1) |> TestRepo.insert()
      {:ok, page_2} = BookPage.changeset(page_2) |> TestRepo.insert()

      assert BookPage.changeset(duplicate_page)
             |> TestRepo.insert()
             |> elem(0) == :error

      [hash_res_1, hash_res_2] =
        from(p in BookPage, where: p.id == ^name)
        |> TestRepo.all
        |> Enum.sort_by(&(&1.page_num))

      assert hash_res_1 == page_1
      assert hash_res_2 == page_2
      assert from(p in BookPage,
               where: p.id == "houseofleaves"
               and p.page_num == 1)
               |> TestRepo.all() == [page_1]
      assert from(p in BookPage,
               where: p.id == ^page_2.id
               and p.page_num == ^page_2.page_num)
             |> TestRepo.all() == [page_2]
    end

    test "'all... in...' query, hard-coded and a variable list of primary hash keys" do
      person1 = %{
                  id: "person-moe",
                  first_name: "Moe",
                  last_name: "Howard",
                  age: 75,
                  email: "moe@stooges.com"
                }
      person2 = %{
                  id: "person-larry",
                  first_name: "Larry",
                  last_name: "Fine",
                  age: 72,
                  email: "larry@stooges.com"
                }

      TestRepo.insert_all(Person, [person1, person2])

      ids = [person1.id, person2.id]
      sorted_ids = Enum.sort(ids)

      assert from(p in Person,
               where: p.id in ^ids,
               select: p.id)
             |> TestRepo.all()
             |> Enum.sort() == sorted_ids
      assert from(p in Person,
               where: p.id in ["person-moe", "person-larry"],
               select: p.id)
             |> TestRepo.all()
             |> Enum.sort() == sorted_ids
    end

    test "'all... in...' query, hard-coded and a variable lists of composite primary keys" do
      page_1 = %{
                id: "page:test-1",
                page_num: 1,
                text: "abc",
              }
      page_2 = %{
                id: "page:test-2",
                page_num: 2,
                text: "def",
              }

      TestRepo.insert_all(BookPage, [page_1, page_2])

      ids = [page_1.id, page_2.id]
      pages = [1, 2]
      sorted_ids = Enum.sort(ids)

      assert from(bp in BookPage,
              where: bp.id in ^ids
                and bp.page_num in ^pages)
             |> TestRepo.all()
             |> Enum.map(&(&1.id))
             |> Enum.sort() == sorted_ids
      assert from(bp in BookPage,
               where: bp.id in ["page:test-1", "page:test-2"]
                 and bp.page_num in [1, 2])
             |> TestRepo.all()
             |> Enum.map(&(&1.id))
             |> Enum.sort() == sorted_ids
    end

    test "'all... in...' query on a hash key global secondary index, hard-coded and variable list, range condition" do
      person_1 = %{
        id: "person-jerrytest",
        first_name: "Jerry",
        last_name: "Garcia",
        age: 55,
        email: "jerry@test.com"
      }
      person_2 = %{
        id: "person-bobtest",
        first_name: "Bob",
        last_name: "Weir",
        age: 70,
        email: "bob@test.com"
      }

      emails = [person_1.email, person_2.email]
      sorted_ids = Enum.sort([person_1.id, person_2.id])

      TestRepo.insert_all(Person, [person_1, person_2])

      assert from(p in Person,
               where: p.email in ^emails,
               select: p.id)
             |> TestRepo.all()
             |> Enum.sort() == sorted_ids
      assert from(p in Person,
               where: p.email in ["jerry@test.com", "bob@test.com"],
               select: p.id)
             |> TestRepo.all()
             |> Enum.sort() == sorted_ids
      assert from(p in Person,
               where: p.email in ^emails
                 and p.age > 69)
             |> TestRepo.all()
             |> Enum.at(0)
             |> Map.get(:id) == person_2.id
      assert from(p in Person,
               where: p.email in ["jerry@test.com", "bob@test.com"]
                 and p.age < 69)
             |> TestRepo.all()
             |> Enum.at(0)
             |> Map.get(:id) == person_1.id
    end

    # DynamoDB has a constraint on the call to BatchGetItem, where attempts to retrieve more than 100 records will be rejected.
    # We allow the user to call all() for more than 100 records by breaking up the requests into blocks of 100.
    # https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_BatchGetItem.html
    test "exceed BatchGetItem limit by 10 records" do
      total_records = 110
      people_to_insert = make_list_of_people_for_batch_insert(total_records)
      person_ids = for person <- people_to_insert, do: person.id

      TestRepo.insert_all(Person, people_to_insert)

      result = from(p in Person,
                 where: p.id in ^person_ids)
               |> TestRepo.all()

      assert length(result) == total_records
    end
  end

  # describe "Repo.all" do
  #   test "batch-get multiple records with an 'all... in...' query on a composite global secondary index (hash and range keys) when querying for a hard-coded and variable list" do
  #     person1 = %{
  #       id: "person:frank",
  #       first_name: "Frank",
  #       last_name: "Sinatra",
  #       age: 45,
  #       email: "frank_sinatra@test.com",
  #     } 
  #     person2 = %{
  #       id: "person:dean",
  #       first_name: "Dean",
  #       last_name: "Martin",
  #       age: 70,
  #       email: "dean_martin@test.com",
  #     }

  #     TestRepo.insert_all(Person, [person1, person2])

  #     first_names = [person1.first_name, person2.first_name]
  #     sorted_ids = Enum.sort([person1.id, person2.id])
  #     var_result = TestRepo.all(from p in Person, where: p.first_name in ^first_names and p.age < 50)
  #                  |> Enum.map(&(&1.id))
  #     hc_result = TestRepo.all(from p in Person, where: p.first_name in ["Frank", "Dean"] and p.age > 40)
  #                 |> Enum.map(&(&1.id))
  #                 |> Enum.sort()

  #     assert var_result == ["person:frank"]
  #     assert hc_result == sorted_ids
  #   end

  #   test "batch-get multiple records on a partial secondary index composite key (hash only)" do
  #     person1 = %{
  #       id: "person:wayne_shorter",
  #       first_name: "Wayne",
  #       last_name: "Shorter",
  #       age: 75,
  #       email: "wayne_shorter@test.com",
  #     }
  #     person2 = %{
  #       id: "person:wayne_campbell",
  #       first_name: "Wayne",
  #       last_name: "Campbell",
  #       age: 36,
  #       email: "wayne_campbell@test.com"
  #     }

  #     TestRepo.insert_all(Person, [person1, person2])

  #     sorted_ids = Enum.sort([person1.id, person2.id])
  #     result = TestRepo.all(from p in Person, where: p.first_name == "Wayne")
  #              |> Enum.map(&(&1.id))
  #              |> Enum.sort()

  #     assert result == sorted_ids
  #   end

  ### MAY BE REDUNDANT
  #   test "batch-insert and query all on a hash key global secondary index" do
  #     person1 = %{
  #                 id: "person-tomtest",
  #                 first_name: "Tom",
  #                 last_name: "Jones",
  #                 age: 70,
  #                 email: "jones@test.com",
  #                 password: "password",
  #               }
  #     person2 = %{
  #                 id: "person-caseytest",
  #                 first_name: "Casey",
  #                 last_name: "Jones",
  #                 age: 114,
  #                 email: "jones@test.com",
  #                 password: "password",
  #               }
  #     person3 = %{
  #                 id: "person-jamestest",
  #                 first_name: "James",
  #                 last_name: "Jones",
  #                 age: 71,
  #                 email: "jones@test.com",
  #                 password: "password",
  #               }

  #     TestRepo.insert_all(Person, [person1, person2, person3])
  #     result = TestRepo.all(from p in Person, where: p.email == "jones@test.com")

  #     assert length(result) == 3
  #   end

  #   test "query all on a multi-condition primary key/global secondary index" do
  #     TestRepo.insert(%Person{
  #                       id: "person:jamesholden",
  #                       first_name: "James",
  #                       last_name: "Holden",
  #                       age: 18,
  #                       email: "jholden@expanse.com",
  #                     })
  #     result = TestRepo.all(from p in Person, where: p.id == "person:jamesholden" and p.email == "jholden@expanse.com")

  #     assert Enum.at(result, 0).first_name == "James"
  #     assert Enum.at(result, 0).last_name == "Holden"
  #   end

  #   test "query all on a composite primary key, using a 'begins_with' fragment on the range key" do
  #     planet1 = %{
  #       id: "planet",
  #       name: "Jupiter",
  #       mass: 6537292902,
  #       moons: MapSet.new(["Io", "Europa", "Ganymede"])
  #     }
  #     planet2 = %{
  #       id: "planet",
  #       name: "Pluto",
  #       mass: 3465,
  #     }

  #     TestRepo.insert_all(Planet, [planet1, planet2])
  #     name_frag = "J"

  #     q = from(p in Planet, where: p.id == "planet" and fragment("begins_with(?, ?)", p.name, ^name_frag))

  #     result = TestRepo.all(q)

  #     assert length(result) == 1
  #   end

  #   test "query all on a partial primary composite index using 'in' and '==' operations" do
  #     planet1 = %{
  #       id: "planet-earth",
  #       name: "Earth",
  #       mass: 476,
  #     }
  #     planet2 = %{
  #       id: "planet-mars",
  #       name: "Mars",
  #       mass: 425,
  #     }

  #     TestRepo.insert_all(Planet, [planet1, planet2])
  #     ids = ["planet-earth", "planet-mars"]
  #     in_q = from(p in Planet, where: p.id in ^ids)
  #     equals_q = from(p in Planet, where: p.id == "planet-earth")
  #     in_result = TestRepo.all(in_q)
  #     equals_result = TestRepo.all(equals_q)

  #     assert length(in_result) == 2
  #     assert length(equals_result) == 1
  #   end

  #   test "query all on a partial secondary index using 'in' and '==' operations" do
  #     planet1 = %{
  #       id: "planet-mercury",
  #       name: "Mercury",
  #       mass: 153,
  #     }
  #     planet2 = %{
  #       id: "planet-saturn",
  #       name: "Saturn",
  #       mass: 409282891,
  #     }

  #     TestRepo.insert_all(Planet, [planet1, planet2])
  #     in_q = from(p in Planet, where: p.name in ["Mercury", "Saturn"])
  #     equals_q = from(p in Planet, where: p.name == "Mercury")
  #     in_result = TestRepo.all(in_q)
  #     equals_result = TestRepo.all(equals_q)

  #     assert length(in_result) == 2
  #     assert length(equals_result) == 1
  #   end

  #   test "query all on global secondary index with a composite key, using a 'begins_with' fragment on the range key" do
  #     person1 = %{
  #                 id: "person-michael-jordan",
  #                 first_name: "Michael",
  #                 last_name: "Jordan",
  #                 age: 52,
  #                 email: "mjordan@test.com",
  #                 password: "password",
  #               }
  #     person2 = %{
  #                 id: "person-michael-macdonald",
  #                 first_name: "Michael",
  #                 last_name: "MacDonald",
  #                 age: 74,
  #                 email: "singin_dude@test.com",
  #                 password: "password",
  #               }

  #     TestRepo.insert_all(Person, [person1, person2])
  #     email_frag = "m"
  #     q = from(p in Person, where: p.first_name == "Michael" and fragment("begins_with(?, ?)", p.email, ^email_frag))

  #     result = TestRepo.all(q)

  #     assert length(result) == 1
  #   end

  #   test "query all on a global secondary index where an :index option has been provided to resolve an ambiguous index choice" do
  #     person1 = %{
  #                 id: "person-methuselah-baby",
  #                 first_name: "Methuselah",
  #                 last_name: "Baby",
  #                 age: 0,
  #                 email: "newborn_baby@test.com",
  #                 password: "password",
  #               }
  #     person2 = %{
  #                 id: "person-methuselah-jones",
  #                 first_name: "Methuselah",
  #                 last_name: "Jones",
  #                 age: 969,
  #                 email: "methuselah@test.com",
  #                 password: "password",
  #               }

  #     TestRepo.insert_all(Person, [person1, person2])

  #     q = from(p in Person, where: p.first_name == "Methuselah" and p.age in [0, 969])
  #     # based on the query, it won't be clear to the adapter whether to choose the first_name_age or age_first_name index - pass the :index option to make sure it queries correctly.
  #     result = TestRepo.all(q, index: "age_first_name")

  #     assert length(result) == 2
  #   end
  # end

  defp make_list_of_people_for_batch_insert(total_records) do
    for i <- 0..total_records, i > 0 do
      id_string = :crypto.strong_rand_bytes(16) |> Base.url_encode64 |> binary_part(0, 16)
      id = "person:" <> id_string

      %{
        id: id,
        first_name: "Batch",
        last_name: "Insert",
        age: i,
        email: "batch_insert#{i}@test.com"
      }
    end
  end

  defp get_datetime_type(datetime) do
    {base_type, datetime_string} =
      case datetime do
        %NaiveDateTime{} ->
          {:naive_datetime, datetime |> NaiveDateTime.to_iso8601()}
        %DateTime{} ->
          {:utc_datetime, datetime |> DateTime.to_iso8601()}
      end

    if String.contains?(datetime_string, "."),
      do: :"#{base_type}_usec",
      else: base_type
  end
end
